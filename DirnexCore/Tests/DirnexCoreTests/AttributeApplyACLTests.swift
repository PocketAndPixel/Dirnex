import Foundation
import Testing

@testable import DirnexCore

/// Propagating an access-control list down a tree (PLAN.md §M14 Slice 4) — the half of the recursive
/// apply that writes something other than a mode word.
///
/// Its own suite because it has its own rules: the list is **replaced**, not merged (order is
/// meaning, so there is no sound fold), it is adjusted to each item's kind on the way in, and it
/// rides in the *same* undo record as the mode change so one ⌘Z puts both halves back.
@Suite("AttributeApplyRunner ACL")
struct AttributeApplyACLTests {
    /// `oleg allow read,delete_child` with both inheritance controls — a list only a directory can
    /// carry whole, which is what makes the adjustment observable.
    private func directoryList() throws -> AccessControlList {
        let subject = try #require(AttributeApplyFixture.currentUserSubject())
        return AccessControlList(entries: [
            ACLEntry(
                subject: subject,
                disposition: .allow,
                inheritance: [.fileInherit, .directoryInherit],
                rights: [.read, .deleteChild]
            )
        ])
    }

    // MARK: - Propagation

    @Test("Every item in the tree receives the list, each adjusted to its own kind")
    func propagatesAdjustedPerKind() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let list = try directoryList()

        let report = try fixture.run(
            AttributeApplyJob(patch: AttributePatch(), accessControlList: list)
        )

        #expect(report.failures.isEmpty, "\(report.failures)")
        // A directory keeps the whole entry…
        let onDirectory = try #require(try fixture.accessControlList("sub").entries.first)
        #expect(onDirectory.rights == [.read, .deleteChild])
        #expect(onDirectory.inheritance == [.fileInherit, .directoryInherit])
        // …and a file gets the same entry with the bits it cannot carry removed.
        let onFile = try #require(try fixture.accessControlList("sub/b.txt").entries.first)
        #expect(onFile.rights == [.read])
        #expect(onFile.inheritance == [])
        #expect(onFile.subject == onDirectory.subject)
    }

    @Test("An item that already has the adjusted list is not written again")
    func alreadyMatchingIsSkipped() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let job = AttributeApplyJob(patch: AttributePatch(), accessControlList: try directoryList())

        let first = try fixture.run(job)
        #expect(try #require(first.attributeApply).changedCount == 6)

        let second = try fixture.run(job)
        let result = try #require(second.attributeApply)
        #expect(result.changedCount == 0, "the adjusted list already matches on every item")
        #expect(result.visitedCount == 6)
    }

    @Test("A job with no list leaves every item's own ACL alone")
    func noListLeavesACLsAlone() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let existing = try directoryList().adjusted(for: .file)
        try AccessControlListIO.write(existing, to: fixture.tree.vfsPath("a.txt"))

        var patch = AttributePatch()
        patch.flagsToSet = .hidden
        _ = try fixture.run(AttributeApplyJob(patch: patch))

        #expect(try fixture.accessControlList("a.txt") == existing)
    }

    @Test("The list replaces what was there, rather than merging with it")
    func replacesRatherThanMerges() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let subject = try #require(AttributeApplyFixture.currentUserSubject())
        try AccessControlListIO.write(
            AccessControlList(entries: [
                ACLEntry(subject: subject, disposition: .deny, rights: [.delete])
            ]),
            to: fixture.tree.vfsPath("a.txt")
        )

        _ = try fixture.run(
            AttributeApplyJob(patch: AttributePatch(), accessControlList: try directoryList())
        )

        let entries = try fixture.accessControlList("a.txt").entries
        #expect(entries.count == 1, "the previous deny is gone, not kept alongside")
        #expect(entries.first?.disposition == .allow)
    }

    // MARK: - Undo

    @Test("One Cmd+Z puts back both the mode and the ACL, for every item")
    func undoRestoresBothHalves() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        var patch = AttributePatch()
        patch.permissionMask = POSIXPermissions(rawValue: 0o7777)
        patch.permissionValues = POSIXPermissions(rawValue: 0o750)
        let report = try fixture.run(
            AttributeApplyJob(patch: patch, accessControlList: try directoryList())
        )
        let result = try #require(report.attributeApply)
        #expect(result.isUndoable)
        #expect(try fixture.accessControlList("a.txt").entries.count == 1)

        let record = try #require(UndoRecord.attributeBatchChange(result.changed))
        let undone = UndoJournal.revert(record, using: fixture.backend)

        #expect(undone.failures.isEmpty, "\(undone.failures)")
        #expect(
            try fixture.accessControlList("a.txt").isEmpty,
            "a file that had no ACL must end with none"
        )
        #expect(try fixture.accessControlList("sub").isEmpty)
        #expect(
            try FileAttributeIO.read(at: fixture.tree.vfsPath("a.txt")).attributes.permissions.rawValue
                == 0o644
        )
    }

    @Test("Undo restores an ACL the item already had, rather than removing it")
    func undoRestoresAPreviousList() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let before = try directoryList().adjusted(for: .file)
        try AccessControlListIO.write(before, to: fixture.tree.vfsPath("a.txt"))

        let subject = try #require(AttributeApplyFixture.currentUserSubject())
        let after = AccessControlList(entries: [
            ACLEntry(subject: subject, disposition: .deny, rights: [.write])
        ])
        let report = try fixture.run(
            AttributeApplyJob(patch: AttributePatch(), accessControlList: after)
        )
        let result = try #require(report.attributeApply)
        let record = try #require(UndoRecord.attributeBatchChange(result.changed))
        _ = UndoJournal.revert(record, using: fixture.backend)

        #expect(try fixture.accessControlList("a.txt") == before)
    }

    // MARK: - Sequencing

    /// `acl_set_file` is `EPERM` while `UF_IMMUTABLE` is set, exactly as `chmod` is — so the ACL is a
    /// step *inside* the plan's unlock → apply → relock window, not a second write beside it.
    @Test("A locked item receives the list in one gesture and stays locked")
    func lockedItemIsUnlockedAndRelocked() throws {
        let fixture = try AttributeApplyFixture()
        defer {
            _ = chflags(fixture.tree.path("a.txt"), 0) // else the temp tree cannot be removed
            fixture.cleanup()
        }
        #expect(chflags(fixture.tree.path("a.txt"), UInt32(UF_IMMUTABLE)) == 0)

        let report = try fixture.run(
            AttributeApplyJob(patch: AttributePatch(), accessControlList: try directoryList())
        )

        #expect(report.failures.isEmpty, "\(report.failures)")
        #expect(try fixture.accessControlList("a.txt").entries.count == 1)
        let flags = try FileAttributeIO.read(at: fixture.tree.vfsPath("a.txt")).attributes.flags
        #expect(flags.contains(.userImmutable), "it must be locked again afterwards")
    }
}
