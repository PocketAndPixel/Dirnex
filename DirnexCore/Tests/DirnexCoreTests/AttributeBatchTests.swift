import Foundation
import Testing

@testable import DirnexCore

/// The multi-selection commit, end to end against **real** temp files (PLAN.md §M14 Slice 4): an
/// ``AttributePatch`` turned into a per-item ``AttributeDiff``, applied through the same
/// ``AttributeChangePlan`` / ``FileAttributeIO`` as the single-item path, and reversed by one batch
/// ``UndoRecord`` — the property the bulk editor rests on.
///
/// The case that matters is two files that do **not** start alike: forcing one bit must leave each
/// file's other bits at its own value, and one Cmd+Z must put both back. A whole-value edit could not
/// express either, which is why the patch exists.
@Suite("AttributeBatch")
struct AttributeBatchTests {
    private let backend = LocalBackend()

    private func read(_ path: VFSPath) throws -> FileAttributes {
        try FileAttributeIO.read(at: path).attributes
    }

    private func applyPatch(_ patch: AttributePatch, to path: VFSPath) throws -> FileAttributes {
        let old = try read(path)
        let plan = AttributeChangePlan(
            diff: patch.diff(against: old), current: old, actsOnLink: false
        )
        try FileAttributeIO.apply(plan, to: path)
        return old
    }

    @Test("forcing one bit across two files leaves each file's other bits untouched")
    func forcedBitPreservesNeighbours() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let fileA = VFSPath.local(try tree.writeFile("a.txt", contents: "a"))
        let fileB = VFSPath.local(try tree.writeFile("b.txt", contents: "b"))
        chmod(fileA.path, 0o600) // owner rw, nothing else
        chmod(fileB.path, 0o664) // owner rw, group rw, other r

        // Force group-read ON for both, touch nothing else.
        var patch = AttributePatch()
        patch.permissionMask[.group, .read] = true
        patch.permissionValues[.group, .read] = true

        _ = try applyPatch(patch, to: fileA)
        _ = try applyPatch(patch, to: fileB)

        // A gained group-read (0o640); B already had it and kept its group-write and other-read.
        #expect(try read(fileA).permissions.rawValue == 0o640)
        #expect(try read(fileB).permissions.rawValue == 0o664)
    }

    @Test("a batch commit reverses as one record, restoring every file")
    func batchUndoRestoresAll() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let fileA = VFSPath.local(try tree.writeFile("a.txt", contents: "a"))
        let fileB = VFSPath.local(try tree.writeFile("b.txt", contents: "b"))
        chmod(fileA.path, 0o600)
        chmod(fileB.path, 0o755)

        var patch = AttributePatch()
        patch.permissionMask[.owner, .execute] = true
        patch.permissionValues[.owner, .execute] = true
        patch.flagsToSet = [.hidden]

        var entries: [UndoRecord.AttributeBatchEntry] = []
        for path in [fileA, fileB] {
            let old = try applyPatch(patch, to: path)
            entries.append(.init(path: path, actsOnLink: false, old: old, new: patch.apply(to: old)))
        }
        // Both files gained owner-execute and the hidden flag.
        #expect(try read(fileA).permissions[.owner, .execute])
        #expect(try read(fileB).permissions[.owner, .execute])
        #expect(try read(fileA).flags.contains(.hidden))
        #expect(try read(fileB).flags.contains(.hidden))

        let record = try #require(UndoRecord.attributeBatchChange(entries))
        #expect(record.label == .changeAttributes)
        #expect(record.steps.count == 2) // one per file, so one Cmd+Z covers both

        let report = UndoJournal.revert(record, using: backend)
        #expect(report.succeeded)
        #expect(try read(fileA).permissions.rawValue == 0o600)
        #expect(try read(fileB).permissions.rawValue == 0o755)
        #expect(!(try read(fileA).flags.contains(.hidden)))
        #expect(!(try read(fileB).flags.contains(.hidden)))
    }

    @Test("an item the patch does not actually change contributes no step")
    func unchangedItemContributesNoStep() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let fileA = VFSPath.local(try tree.writeFile("a.txt", contents: "a"))
        let fileB = VFSPath.local(try tree.writeFile("b.txt", contents: "b"))
        chmod(fileA.path, 0o644) // already has group-read
        chmod(fileB.path, 0o600) // does not

        var patch = AttributePatch()
        patch.permissionMask[.group, .read] = true
        patch.permissionValues[.group, .read] = true

        var entries: [UndoRecord.AttributeBatchEntry] = []
        for path in [fileA, fileB] {
            let old = try read(path)
            entries.append(.init(path: path, actsOnLink: false, old: old, new: patch.apply(to: old)))
        }
        // A was already 0o644 → no change → no step; only B contributes.
        let record = try #require(UndoRecord.attributeBatchChange(entries))
        #expect(record.steps.count == 1)
    }

    @Test("a batch that changes nothing produces no record")
    func noChangeNoRecord() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let fileA = VFSPath.local(try tree.writeFile("a.txt", contents: "a"))
        let old = try read(fileA)
        let entry = UndoRecord.AttributeBatchEntry(
            path: fileA, actsOnLink: false, old: old, new: old
        )
        #expect(UndoRecord.attributeBatchChange([entry]) == nil)
    }
}
