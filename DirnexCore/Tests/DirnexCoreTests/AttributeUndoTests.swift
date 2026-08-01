import Foundation
import Testing

@testable import DirnexCore

/// Undo and redo of an attributes change, against **real** temp files with the OS reading back the
/// result (PLAN.md §M14 Slice 4). A change is a reversible action like a copy or a rename, so it
/// goes through the same `UndoRecord`/`UndoJournal` machinery — but its one step is executed through
/// ``FileAttributeIO`` rather than the `VFSBackend`, which is what these tests pin.
///
/// The property is the journal's usual one, specialized: apply a change, revert it, and the item's
/// attributes are what they were. The locked-file case is here on purpose — restoring a mode on a
/// file that is still `UF_IMMUTABLE` re-runs the unlock/relock ordering at *undo* time, which no
/// forward test exercises.
@Suite("AttributeUndo")
struct AttributeUndoTests {
    private let backend = LocalBackend()

    private func read(_ path: VFSPath) throws -> FileAttributes {
        try FileAttributeIO.read(at: path).attributes
    }

    private func applyForward(from old: FileAttributes, to new: FileAttributes, on path: VFSPath) throws {
        try FileAttributeIO.apply(
            AttributeChangePlan(
                diff: AttributeDiff(from: old, to: new),
                current: old,
                actsOnLink: false
            ),
            to: path
        )
    }

    @Test("undoing a mode change restores the prior mode")
    func undoRestoresMode() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        chmod(path.path, 0o644)

        let old = try read(path)
        var new = old
        new.permissions = POSIXPermissions(rawValue: 0o600)
        try applyForward(from: old, to: new, on: path)
        #expect(try read(path).permissions.rawValue == 0o600)

        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: old, to: new)
        )
        #expect(record.label == .changeAttributes)
        let report = UndoJournal.revert(record, using: backend)
        #expect(report.succeeded)
        #expect(try read(path).permissions.rawValue == 0o644)
    }

    @Test("redo re-applies the change the inverse record carries")
    func redoReappliesMode() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        chmod(path.path, 0o644)

        let old = try read(path)
        var new = old
        new.permissions = POSIXPermissions(rawValue: 0o600)
        try applyForward(from: old, to: new, on: path)

        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: old, to: new)
        )
        _ = UndoJournal.revert(record, using: backend) // undo → 0644
        #expect(try read(path).permissions.rawValue == 0o644)

        // Redo is the inverted record run through the same executor.
        let redo = UndoJournal.revert(record.inverted, using: backend)
        #expect(redo.succeeded)
        #expect(try read(path).permissions.rawValue == 0o600)
    }

    @Test("undoing a flag change clears the flag it set")
    func undoRestoresFlags() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))

        let old = try read(path)
        #expect(!old.flags.contains(.hidden))
        var new = old
        new.flags.insert(.hidden)
        try applyForward(from: old, to: new, on: path)
        #expect(try read(path).flags.contains(.hidden))

        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: old, to: new)
        )
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(!(try read(path).flags.contains(.hidden)))
    }

    @Test("undoing a mode change on a still-locked file restores it in one gesture")
    func undoRestoresModeOnLockedFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        chmod(path.path, 0o644)
        chflags(path.path, UInt32(UF_IMMUTABLE))
        defer { chflags(path.path, 0) } // FileManager.removeItem fails while immutable (docs/NOTES.md)

        let old = try read(path)
        #expect(old.flags.contains(.userImmutable))
        var new = old
        new.permissions = POSIXPermissions(rawValue: 0o600) // still locked
        try applyForward(from: old, to: new, on: path)
        #expect(try read(path).permissions.rawValue == 0o600)
        #expect(try read(path).flags.contains(.userImmutable))

        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: old, to: new)
        )
        // Undo restores the old mode against a file that is still immutable: the plan built at revert
        // time must unlock → chmod → relock, or this is the bare EPERM the whole design avoids.
        let report = UndoJournal.revert(record, using: backend)
        #expect(report.succeeded)
        #expect(try read(path).permissions.rawValue == 0o644)
        #expect(try read(path).flags.contains(.userImmutable))
    }

    @Test("an unchanged commit produces no undo record")
    func builderReturnsNilForNoChange() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
        let attributes = try read(path)
        #expect(
            UndoRecord.attributeChange(at: path, actsOnLink: false, from: attributes, to: attributes) == nil
        )
    }

    /// Undo is not symmetric with the change it reverses, and this is the case that proves it.
    ///
    /// A file's group is inherited from its parent, so an item can sit in a group its owner does not
    /// belong to. The panel lets them move it *out* of that group — legal, `chgrp` to a group you are
    /// in — and moving it *back* is `EPERM`. Found by undoing a real edit in the app; before the
    /// guard it surfaced as the raw errno, which the app renders as "Dirnex may need Full Disk
    /// Access": true of the errno, wrong about the cause, and pointing at a settings pane that cannot
    /// help. The named reason is what the user can act on.
    @Test("undoing a move out of a foreign group names the privilege, not a bare errno")
    func undoIntoAForeignGroupIsNamed() throws {
        let actor = UserContext.current()
        // A gid nobody is in. Skipping rather than asserting keeps this honest if run as root.
        let foreign: UInt32 = 1 // daemon
        guard !actor.isSuperUser, !actor.groupIDs.contains(foreign) else { return }

        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))

        // The undo half only: put the file back into a group the caller cannot join.
        var diff = AttributeDiff()
        diff.groupID = foreign
        var failures: [OperationItemFailure] = []
        UndoJournal.restoreAttributes(diff, at: path, actsOnLink: false, failures: &failures)

        let failure = try #require(failures.first)
        #expect(failure.error == .unsupported(.attributeRestoreNeedsAdministrator(name: "f.txt")))
        // And it refused *before* touching the file, rather than half-applying.
        #expect(try read(path).groupID != foreign)
    }

    @Test("the attribute step survives the journal's JSON round-trip")
    func stepSurvivesJSONRoundTrip() throws {
        let path = VFSPath.local("/tmp/f.txt")
        var new = FileAttributes(
            permissions: POSIXPermissions(rawValue: 0o644),
            flags: BSDFileFlags(),
            ownerID: 501, groupID: 20,
            accessDate: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            creationDate: Date(timeIntervalSince1970: 3)
        )
        let old = new
        new.permissions = POSIXPermissions(rawValue: 0o600)
        new.flags.insert(.userImmutable)
        let record = try #require(
            UndoRecord.attributeChange(at: path, actsOnLink: true, from: old, to: new)
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(UndoRecord.self, from: data)
        #expect(decoded == record)
    }
}
