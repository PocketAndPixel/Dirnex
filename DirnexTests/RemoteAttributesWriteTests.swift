import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A backend that answers the two write verbs, so the panel's editing half is reachable with no
/// server (PLAN.md §M25 Slice 5).
///
/// It records what it was asked to send and what it answers, because the claim under test is
/// **which steps reach the wire** — a fake that merely succeeded would prove the panel calls
/// something, not that it calls the right thing.
final class WritingBackend: VFSBackend, @unchecked Sendable {
    let id: VFSBackendID
    var offers: RemoteMetadataCapabilities
    /// What the panel sent, in order.
    private(set) var sent: [[RemoteMetadataStep]] = []
    /// What `applyMetadata` answers — empty is "everything took".
    var refusals: [RemoteMetadataRefusal] = []
    /// What a re-read reports. The whole point of the read-back is that this may disagree with what
    /// was asked, so the test sets it directly.
    var landed: FileEntry?

    init(id: VFSBackendID, offers: RemoteMetadataCapabilities) {
        self.id = id
        self.offers = offers
    }

    var capabilities: VFSCapabilities { [.read, .write] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard let landed else { throw VFSError.notFound(path) }
        return landed
    }

    func editableMetadata(at path: VFSPath) -> RemoteMetadataCapabilities {
        path.backend == id ? offers : []
    }

    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        at path: VFSPath
    ) throws -> [RemoteMetadataRefusal] {
        sent.append(steps)
        return refusals
    }
}

/// Get Info's **write** half (PLAN.md §M25 Slice 5).
///
/// The pure rules live in the core and are tested there; what these pin is the wiring nothing else
/// can see — that the panel offers controls only where the connection answers, that Save sends the
/// steps for the fields that changed and no others, and that a server which stored something other
/// than what was asked is reported rather than believed.
@Suite("Remote Get Info ▸ writing")
@MainActor
struct RemoteAttributesWriteTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))

    private func entry(_ name: String = "report.txt", permissions: UInt16? = 0o644) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/home/oleg/\(name)"),
            name: name,
            kind: .file,
            byteSize: 10,
            modificationDate: epoch,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: permissions,
            ownerName: "oleg",
            groupName: "staff",
            inode: 1
        )
    }

    private func entry(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: 10,
            modificationDate: epoch,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    private func panel(
        _ entry: FileEntry,
        offering: RemoteMetadataCapabilities
    ) -> (RemoteAttributesController, WritingBackend) {
        let backend = WritingBackend(id: backendID, offers: offering)
        let controller = RemoteAttributesController(
            entry: entry,
            backend: backend,
            editability: RemoteAttributeEditability.decide(
                for: entry,
                capabilities: backend.editableMetadata(at: entry.path)
            )
        )
        controller.loadViewIfNeeded()
        return (controller, backend)
    }

    @Test("an SFTP row draws a live mode grid and no date control")
    func sftpDrawsTheModeGridOnly() {
        let (controller, _) = panel(entry(), offering: .sftp)
        // Twelve boxes: nine rwx and the three special bits `chmod` is the only route to.
        #expect(controller.modeBoxes.count == 9)
        #expect(controller.specialBoxes.count == 3)
        #expect(controller.modificationPicker == nil)
    }

    @Test("an FTP row draws both, which is the richer protocol here")
    func ftpDrawsBoth() {
        let (controller, _) = panel(entry(), offering: .ftp)
        #expect(controller.modeBoxes.count == 9)
        #expect(controller.modificationPicker != nil)
    }

    @Test("a backend with no write verbs draws no controls at all")
    func noVerbsDrawsNoControls() {
        let (controller, _) = panel(entry(), offering: [])
        #expect(controller.modeBoxes.isEmpty)
        #expect(controller.specialBoxes.isEmpty)
        #expect(controller.modificationPicker == nil)
        #expect(controller.editability.isReadOnly)
    }

    @Test("an untouched panel has nothing to send")
    func untouchedPanelSendsNothing() {
        let (controller, _) = panel(entry(), offering: .sftp)
        #expect(controller.pendingChange.isEmpty)
        // The narrowness half: the grid really did start from the entry's own mode, so "nothing to
        // send" is not the answer of a grid that was never populated.
        #expect(controller.editedPermissions.rawValue == 0o644)
    }

    @Test("ticking a box sends exactly the mode the grid spells")
    func tickingABoxSendsThatMode() async throws {
        let (controller, backend) = panel(entry(), offering: .sftp)
        backend.landed = entry(permissions: 0o664)
        let write = try #require(controller.modeBoxes.first {
            $0.cls == .group && $0.access == .write
        })
        write.box.state = .on
        controller.editChanged(nil)

        #expect(controller.pendingChange.permissions?.rawValue == 0o664)
        controller.save(nil)
        try await settle { !backend.sent.isEmpty }
        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o664))]])
    }

    @Test("a special bit rides the same chmod, which is its only route over the wire")
    func specialBitIsSent() async throws {
        let (controller, backend) = panel(entry(permissions: 0o755), offering: .sftp)
        backend.landed = entry(permissions: 0o4755)
        let setUID = try #require(controller.specialBoxes.first { $0.bit == .setUserID })
        setUID.box.state = .on
        controller.editChanged(nil)

        controller.save(nil)
        try await settle { !backend.sent.isEmpty }
        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o4755))]])
    }

    @Test("a mode the server silently did not store leaves the panel showing the truth")
    func silentDowngradeIsShownAndReported() async throws {
        // The measurement this slice is built on: `chmod 2755` on a file whose group the account is
        // not in exits 0, prints nothing, and stores 0755. The panel must not report success.
        let (controller, backend) = panel(entry(permissions: 0o755), offering: .sftp)
        backend.landed = entry(permissions: 0o755) // the server kept the old mode
        let setGID = try #require(controller.specialBoxes.first { $0.bit == .setGroupID })
        setGID.box.state = .on
        controller.editChanged(nil)
        #expect(controller.pendingChange.permissions?.rawValue == 0o2755)

        // Wait on a witness only a *finished* save can produce. The entry's own mode is the wrong
        // one here: the whole scenario is that it did not change, so a predicate reading it is true
        // before the write starts and waits for nothing — which is how the first version of this
        // test read the panel mid-flight and reported a bug in the code (docs/NOTES.md ▸ Testing: a
        // bounded wait that gives up silently).
        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o2755))]])
        // Redrawn from the server's answer, so what is on screen is what the item carries — not the
        // set-group-ID bit that was asked for and silently dropped.
        #expect(controller.editedPermissions.rawValue == 0o755)
        #expect(controller.specialBoxes.allSatisfy { $0.box.state == .off })
        // And the user is *told*. Redrawing alone is not enough: the panel would show the same thing
        // whether or not it noticed, so without this the test measures the redraw and a build that
        // believed the clean exit would pass it.
        let verdict = try #require(controller.lastVerdict)
        #expect(verdict.refused == [.permissions])
        #expect(!verdict.isComplete)
    }

    @Test("a save the server honoured reports nothing refused")
    func honouredSaveIsComplete() async throws {
        // The narrowness half of the read-back: it must not report a loss on a write that landed, or
        // "check the answer" quietly becomes "distrust every answer".
        let (controller, backend) = panel(entry(permissions: 0o644), offering: .sftp)
        backend.landed = entry(permissions: 0o664)
        let write = try #require(controller.modeBoxes.first {
            $0.cls == .group && $0.access == .write
        })
        write.box.state = .on
        controller.editChanged(nil)

        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        let verdict = try #require(controller.lastVerdict)
        #expect(verdict.isComplete)
        #expect(verdict.refused.isEmpty)
    }

    /// The pane's own wiring, which nothing above reaches: every test here builds the controller
    /// directly, so a pane that opened every remote panel read-only would leave them all green.
    @Test("the pane asks the row's own connection what may be changed")
    func paneAsksTheRowsConnection() {
        // Driven through the *pane's* own method, on a pane built over a real routing backend with a
        // real connection registered — because every other test here constructs the controller
        // directly, so a pane that always answered `.readOnly` would leave them all green and every
        // remote panel in the app read-only with nothing to see.
        //
        // Registering costs no round trip: `connectSFTP` files a transport under a descriptor and
        // the network does not happen until a listing. The view is never loaded, so the pane lists
        // nothing.
        let composite = CompositeBackend(local: LocalBackend())
        let location = SFTPLocation(host: "srv", username: "oleg")
        composite.connectSFTP(location: location, authentication: .key(identityFile: "/dev/null"))
        let row = entry()
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )

        #expect(pane.remoteEditability(for: row).allows(.permissions))
        // The narrowness half, on the same pane: a row on no connection is read-only rather than
        // taking the connected account's answer.
        let elsewhere = VFSPath(
            backend: .sftp(SFTPLocation(host: "other", username: "oleg")),
            path: "/home/oleg/a.txt"
        )
        #expect(pane.remoteEditability(for: entry(at: elsewhere)).isReadOnly)
    }

    @Test("each refusal names something true")
    func refusalWordingCoversEveryCombination() {
        // Static and window-free on purpose: the part worth pinning is that no combination produces
        // a sentence about a field that was fine.
        let mode = RemoteAttributesController.partialDetail([.permissions])
        let time = RemoteAttributesController.partialDetail([.modificationTime])
        let both = RemoteAttributesController.partialDetail([.permissions, .modificationTime])
        #expect(mode != time)
        #expect(both != mode && both != time)
        #expect(!RemoteAttributesController.partialDetail([]).isEmpty)
    }

    /// Poll rather than spinning the run loop: a detached read's continuation needs the main actor
    /// to *suspend*, which a run-loop spin never does (docs/NOTES.md ▸ Testing).
    private func settle(
        within seconds: Double = 10,
        until predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }
}
