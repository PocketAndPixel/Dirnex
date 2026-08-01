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

    /// The same criterion on the ACL path, and the reason the ACL is a plan *step*: probed
    /// 2026-07-31, `acl_set_file` is `EPERM` on a locked file exactly as `chmod` is (`chmod: Failed
    /// to set ACL on file: Operation not permitted`). One gesture writes the mode *and* the ACL and
    /// leaves the file locked.
    @Test("a locked file's ACL and mode change together in one gesture, and it stays locked")
    func lockedFileACLInOneGesture() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            chmod(path.path, 0o644)
            chflags(path.path, UInt32(UF_IMMUTABLE))

            let uid = getuid()
            let list = AccessControlList(entries: [
                ACLEntry(
                    subject: ACLSubject(
                        kind: .user,
                        guid: try #require(ACLIdentity.guid(forUserID: uid)),
                        name: NSUserName(),
                        numericID: uid
                    ),
                    disposition: .deny,
                    rights: [.delete]
                )
            ])

            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.permissions = POSIXPermissions(rawValue: 0o600)
            let plan = AttributeChangePlan(
                diff: AttributeDiff(from: current, to: desired),
                current: current,
                actsOnLink: false,
                accessControlList: list
            )
            #expect(plan.steps.count == 4) // unlock, chmod, acl_set, relock
            try FileAttributeIO.apply(plan, to: path)

            let after = try FileAttributeIO.read(at: path).attributes
            #expect(after.permissions.rawValue == 0o600)
            #expect(after.flags.isLocked)
            let readBack = try AccessControlListIO.read(at: path)
            #expect(readBack.entries.count == 1)
            #expect(readBack.entries[0].disposition == .deny)

            chflags(path.path, 0) // so the tree can be torn down
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

    // MARK: - The side effects the plan repairs (Slice 4 probe, 2026-07-31)

    /// The negative control, and the reason the two tests below exist at all: this asserts that the
    /// **OS really does** drag the birth time back when the mtime moves before it. Without it, a
    /// macOS that stopped doing so would leave the repair vestigial and every other test still green.
    @Test("the OS drags the birth time back when an mtime is set before it")
    func kernelPullsBirthTimeBack() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let born = try FileAttributeIO.read(at: path).attributes.creationDate
            // A bare utimes, with no plan involved — exactly what the repair is there to catch.
            let past = Date(timeIntervalSince1970: 1_000_000_000)
            var times = [
                timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0),
                timeval(tv_sec: Int(past.timeIntervalSince1970), tv_usec: 0)
            ]
            #expect(utimes(path.path, &times) == 0)
            let after = try FileAttributeIO.read(at: path).attributes
            #expect(after.creationDate < born)
        }
    }

    /// And with the plan in charge, the creation date the user never touched survives.
    @Test("a modification date moved into the past leaves the creation date alone")
    func preservesCreationDateUnderTheDrag() throws {
        try withTree { tree in
            let path = VFSPath.local(try tree.writeFile("f.txt", contents: "hi"))
            let current = try FileAttributeIO.read(at: path).attributes
            var desired = current
            desired.modificationDate = Date(timeIntervalSince1970: 1_000_000_000)
            try applyChange(from: current, to: desired, on: path)

            let after = try FileAttributeIO.read(at: path).attributes
            #expect(Int(after.modificationDate.timeIntervalSince1970) == 1_000_000_000)
            #expect(
                Int(after.creationDate.timeIntervalSince1970)
                    == Int(current.creationDate.timeIntervalSince1970)
            )
        }
    }

    /// `chgrp` is a `chown`, and `chown(2)` clears set-uid for an unprivileged caller — so a
    /// group-only change has to re-write the mode. Runs against two groups the caller really belongs
    /// to, since a `chgrp` to any other is `EPERM`.
    @Test("a group-only change keeps the set-uid bit the user never touched")
    func preservesSetUserIDAcrossAChgrp() throws {
        let actor = UserContext.current()
        guard let other = actor.groupIDs.first(where: { $0 != getgid() }) else { return }
        try withTree { tree in
            let file = try tree.writeFile("f.txt", contents: "hi")
            let path = VFSPath.local(file)
            #expect(chmod(file, 0o4755) == 0)

            let current = try FileAttributeIO.read(at: path).attributes
            #expect(current.permissions.setUserID)
            var desired = current
            desired.groupID = other
            try applyChange(from: current, to: desired, on: path)

            let after = try FileAttributeIO.read(at: path).attributes
            #expect(after.groupID == other)
            #expect(after.permissions.setUserID)
        }
    }
}
