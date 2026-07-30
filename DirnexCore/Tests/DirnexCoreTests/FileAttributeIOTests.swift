import Foundation
import Testing

@testable import DirnexCore

/// The reader and applier against **real** temp files, with the OS reading back what was written.
/// Every case here is one the probe (2026-07-29) said an owner can do unprivileged; the root-only
/// cases live in ``AttributePrivilege`` as a table, not here.
@Suite("FileAttributeIO")
struct FileAttributeIOTests {
    private func withTree(_ body: (TempTree) throws -> Void) throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try body(tree)
    }

    /// Apply the diff that turns `current` into `desired`, the way the panel would.
    private func applyChange(
        from current: FileAttributes,
        to desired: FileAttributes,
        on path: VFSPath
    ) throws {
        try FileAttributeIO.apply(
            AttributeChangePlan(
                diff: AttributeDiff(from: current, to: desired), current: current, actsOnLink: false
            ),
            to: path
        )
    }

    @Test("reads a file's attributes back the way chmod set them")
    func reads() throws {
        try withTree { tree in
            let file = try tree.writeFile("f.txt", contents: "hi")
            chmod(file, 0o640)
            let reading = try FileAttributeIO.read(at: .local(file))
            #expect(reading.attributes.permissions.rawValue == 0o640)
            #expect(reading.attributes.ownerID == getuid())
            #expect(!reading.isSymlink)
        }
    }

    @Test("a plain mode change round-trips through the OS")
    func appliesMode() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.permissions = POSIXPermissions(rawValue: 0o600)
            try applyChange(from: current, to: desired, on: path)
            #expect(try FileAttributeIO.read(at: path).attributes.permissions.rawValue == 0o600)
        }
    }

    @Test("setting the hidden flag is visible on read-back")
    func appliesFlag() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.flags = [.hidden]
            try applyChange(from: current, to: desired, on: path)
            #expect(try FileAttributeIO.read(at: path).attributes.flags.contains(.hidden))
        }
    }

    /// The headline exit criterion, proven live: changing the mode of a **locked** file works in one
    /// gesture, no root, and the file stays locked. Getting the plan wrong here surfaces as the
    /// `EPERM` this whole design exists to avoid.
    @Test("a locked file's mode changes in one gesture and stays locked")
    func lockedFileInOneGesture() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            chmod(path.path, 0o644)

            // Lock it.
            let unlocked = try FileAttributeIO.read(at: path).attributes
            var locked = unlocked
            locked.flags = [.userImmutable]
            try applyChange(from: unlocked, to: locked, on: path)
            #expect(try FileAttributeIO.read(at: path).attributes.flags.isLocked)

            // Change its mode while it is locked — the plan unlocks, applies, relocks.
            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.permissions = POSIXPermissions(rawValue: 0o600)
            let plan = AttributeChangePlan(
                diff: AttributeDiff(from: current, to: desired), current: current, actsOnLink: false
            )
            #expect(plan.steps.count == 3) // unlock, chmod, relock
            try FileAttributeIO.apply(plan, to: path)

            let after = try FileAttributeIO.read(at: path).attributes
            #expect(after.permissions.rawValue == 0o600)
            #expect(after.flags.isLocked)

            // Unlock so the tree can be torn down (removeItem fails on an immutable file).
            var cleared = after
            cleared.flags = []
            try applyChange(from: after, to: cleared, on: path)
        }
    }

    @Test("times and creation date round-trip through the OS")
    func appliesTimes() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.modificationDate = Date(timeIntervalSince1970: 1_234_567_890)
            desired.creationDate = Date(timeIntervalSince1970: 1_111_111_111)
            try applyChange(from: current, to: desired, on: path)
            let after = try FileAttributeIO.read(at: path).attributes
            #expect(Int(after.modificationDate.timeIntervalSince1970) == 1_234_567_890)
            #expect(Int(after.creationDate.timeIntervalSince1970) == 1_111_111_111)
        }
    }

    @Test("a chgrp to a group you already belong to succeeds")
    func appliesGroupNoOp() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let current = try FileAttributeIO.read(at: path).attributes
            // Re-setting the current group is a chown the owner is always allowed to make.
            var diff = AttributeDiff()
            diff.groupID = current.groupID
            try FileAttributeIO.apply(
                AttributeChangePlan(diff: diff, current: current, actsOnLink: false), to: path
            )
            #expect(try FileAttributeIO.read(at: path).attributes.groupID == current.groupID)
        }
    }

    @Test("a symlink reads as itself, not its target")
    func symlinkReadsLink() throws {
        try withTree { tree in
            _ = try tree.writeFile("target.txt", contents: "hi")
            try tree.symlink("link", to: tree.path("target.txt"))
            let reading = try FileAttributeIO.read(at: tree.vfsPath("link"))
            #expect(reading.isSymlink)
        }
    }
}
