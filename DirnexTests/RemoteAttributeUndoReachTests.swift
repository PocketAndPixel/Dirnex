import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// ⌘Z after a remote Get Info save — the app-side half of the journal step
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// The core suite pins what goes on the stack and what the step does to a server. What only this
/// target can ask is whether anything ever *reaches* the stack: the panel had no journaling hook at
/// all until this pass, and a panel that still had none would save exactly as it does now, with
/// both suites green and every remote change quietly a one-way door. So both ends are driven here —
/// the panel handing a record over after a save that landed, and the pane wiring that hand-over to
/// the window.
@Suite("Remote Get Info ▸ undo")
@MainActor
struct RemoteAttributeUndoReachTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let backendID = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))

    private func entry(permissions: UInt16? = 0o644) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/home/oleg/report.txt"),
            name: "report.txt",
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

    private func panel(
        _ entry: FileEntry,
        offering: RemoteMetadataCapabilities = .sftp
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

    /// Tick the group-write box, which takes 0o644 to 0o664.
    private func tickGroupWrite(_ controller: RemoteAttributesController) throws {
        let write = try #require(controller.modeBoxes.first {
            $0.cls == .group && $0.access == .write
        })
        write.box.state = .on
        controller.editChanged(nil)
    }

    @Test("a save that landed hands the window a record carrying the previous mode")
    func landedSaveIsJournaled() async throws {
        let (controller, backend) = panel(entry())
        backend.landed = entry(permissions: 0o664)
        try tickGroupWrite(controller)

        var records: [UndoRecord] = []
        controller.recordUndo = { records.append($0) }
        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        let record = try #require(records.first)
        #expect(record.label == .changeAttributes)
        guard case let .restoreRemoteAttributes(_, apply, reverse) = try #require(
            record.steps.first
        ) else {
            Issue.record("expected a remote attributes step")
            return
        }
        // The values the panel had going in — which is why the record is built *before* `reload`
        // replaces the entry with the server's answer. Reading them afterwards would journal the
        // new mode in both directions and make ⌘Z a no-op.
        #expect(apply.permissions?.rawValue == 0o644)
        #expect(reverse.permissions?.rawValue == 0o664)
    }

    @Test("a save the server did not act on journals nothing")
    func unchangedSaveIsNotJournaled() async throws {
        // The narrowness half: an entry on the stack that reverses nothing costs the user a ⌘Z
        // that appears to do something and does not, and pushes a real record further down.
        let (controller, backend) = panel(entry())
        backend.landed = entry(permissions: 0o644) // the server kept what was there
        try tickGroupWrite(controller)

        var records: [UndoRecord] = []
        controller.recordUndo = { records.append($0) }
        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        #expect(backend.sent == [[.setMode(POSIXPermissions(rawValue: 0o664))]])
        #expect(records.isEmpty)
    }

    @Test("undoing the record sends the previous mode back through the same connection")
    func undoingSendsThePreviousModeBack() async throws {
        // End to end against one fake: the panel's save, the record it produced, and the core's
        // executor writing through the very backend the panel wrote through.
        let (controller, backend) = panel(entry())
        backend.landed = entry(permissions: 0o664)
        try tickGroupWrite(controller)

        var records: [UndoRecord] = []
        controller.recordUndo = { records.append($0) }
        var applied = 0
        controller.onApplied = { applied += 1 }
        controller.save(nil)
        try await settle { applied == 1 }

        // The server takes the reversal, so the read-back reports the mode the item started with.
        backend.landed = entry(permissions: 0o644)
        let report = UndoJournal.revert(try #require(records.first), using: backend)
        #expect(report.succeeded)
        #expect(backend.sent.last == [.setMode(POSIXPermissions(rawValue: 0o644))])
    }

    @Test("the pane wires the panel's journaling to the window")
    func paneWiresJournalingToTheWindow() {
        // Nothing above reaches this: every test here builds the controller directly, so a pane
        // that never set the hook would leave them all green and no remote save undoable. Built
        // rather than presented — a real window in the test host destabilizes its neighbours.
        let host = StubPanelHost()
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        pane.host = host

        let controller = pane.remoteAttributesController(for: entry())
        let record = try? #require(UndoRecord.remoteAttributeChange(
            from: entry(permissions: 0o644),
            asked: RemoteAttributeChange(permissions: POSIXPermissions(rawValue: 0o664)),
            verdict: RemoteAttributeVerdict(refused: [], landed: entry(permissions: 0o664))
        ))
        guard let record else { return }
        controller.recordUndo?(record)

        // Not merely "the hook is non-nil": a closure that dropped the record would pass that.
        #expect(host.recordedUndo.map(\.id) == [record.id])
        // And the other hook is still wired, so the split did not lose one while gaining one.
        #expect(controller.onApplied != nil)
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
