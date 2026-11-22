import Foundation
import Testing

@testable import DirnexCore

/// What the batch escalation makes of a run (PLAN.md §M40 Slice 4): every item read back, journaled
/// as it is on disk rather than as it was asked, and the retry of a recursive run's root-only items.
@Suite("EscalatedAttributeBatch outcome")
struct EscalatedAttributeBatchOutcomeTests {
    private let epoch = EscalatedBatchSupport.epoch

    private func attributes(mode: UInt16 = 0o644, flags: BSDFileFlags = []) -> FileAttributes {
        EscalatedBatchSupport.attributes(mode: mode, flags: flags)
    }

    private func item(_ path: String, to new: UInt16) -> EscalatedAttributeBatch.Item {
        EscalatedBatchSupport.item(path, to: new)
    }

    private func runShell(_ body: String) throws -> (status: Int32, stderr: String) {
        try EscalatedBatchSupport.runShell(body)
    }

    private func diskItem(
        _ fixture: AttributeApplyFixture,
        _ relative: String,
        mode: UInt16
    ) throws -> EscalatedAttributeBatch.Item {
        try EscalatedBatchSupport.diskItem(fixture, relative, mode: mode)
    }

    // MARK: - Judging what landed

    @Test("Only the fields the plan writes are journaled, whatever else moved")
    func journalsOnlyPlannedFields() {
        let batch = EscalatedAttributeBatch(items: [item("/a", to: 0o600)])
        var after = attributes(mode: 0o600)
        after.modificationDate = epoch.addingTimeInterval(3600) // someone else wrote the file
        after.groupID = 12

        let outcome = batch.outcome { _ in .init(attributes: after) }

        let entry = outcome.changed.first
        #expect(entry?.new.permissions.rawValue == 0o600)
        #expect(entry?.new.modificationDate == epoch)
        #expect(entry?.new.groupID == 20)
        #expect(outcome.unchanged.isEmpty)
    }

    @Test("A partial landing journals what moved and still counts as unchanged")
    func partialLanding() {
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: 0o600)
        diff.flags = .hidden
        let batch = EscalatedAttributeBatch(items: [.init(
            path: VFSPath.local("/a"), actsOnLink: false, current: attributes(), diff: diff
        )])
        let after = attributes(mode: 0o600) // the chmod landed, the chflags did not

        let outcome = batch.outcome { _ in .init(attributes: after) }

        #expect(outcome.changed.first?.new.permissions.rawValue == 0o600)
        #expect(outcome.changed.first?.new.flags == [])
        #expect(outcome.unchanged == [VFSPath.local("/a")])
    }

    @Test("An omitted Created date is not a failure, and is not journaled")
    func omittedCreationDate() {
        var diff = AttributeDiff()
        diff.permissions = POSIXPermissions(rawValue: 0o600)
        diff.creationDate = epoch.addingTimeInterval(-86400)
        let batch = EscalatedAttributeBatch(items: [.init(
            path: VFSPath.local("/a"), actsOnLink: false, current: attributes(), diff: diff
        )])

        let outcome = batch.outcome { _ in .init(attributes: attributes(mode: 0o600)) }

        #expect(outcome.unchanged.isEmpty)
        #expect(outcome.changed.first?.new.creationDate == epoch)
    }

    @Test("Times count as landed to the second, which is what touch writes")
    func wholeSecondTimes() {
        var diff = AttributeDiff()
        diff.modificationDate = epoch.addingTimeInterval(100.6)
        let batch = EscalatedAttributeBatch(items: [.init(
            path: VFSPath.local("/a"), actsOnLink: false, current: attributes(), diff: diff
        )])
        var after = attributes()
        after.modificationDate = epoch.addingTimeInterval(100)

        #expect(batch.outcome { _ in .init(attributes: after) }.unchanged.isEmpty)
        after.modificationDate = epoch.addingTimeInterval(99)
        #expect(batch.outcome { _ in .init(attributes: after) }.unchanged == [VFSPath.local("/a")])
    }

    @Test("An item that cannot be read back is unchanged and journals nothing")
    func unreadable() {
        let batch = EscalatedAttributeBatch(items: [item("/a", to: 0o600)])
        let outcome = batch.outcome { _ in nil }
        #expect(outcome.changed.isEmpty)
        #expect(outcome.unchanged == [VFSPath.local("/a")])
    }

    @Test("Over the journal limit nothing is journaled, and the count still says what changed")
    func journalLimit() {
        let batch = EscalatedAttributeBatch(items: [item("/a", to: 0o600), item("/b", to: 0o600)])
        let outcome = batch.outcome(journalLimit: 1) { _ in .init(
            attributes: attributes(mode: 0o600)
        ) }
        #expect(outcome.changed.isEmpty)
        #expect(outcome.changedCount == 2)
        #expect(!outcome.isUndoable)
    }

    @Test("A written list is judged and journaled whole")
    func accessControlList() throws {
        let subject = ACLSubject(
            kind: .group, guid: "ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C", name: "everyone",
            numericID: 12
        )
        let entry = ACLEntry(
            subject: subject, disposition: .deny, inheritance: [], rights: [.delete],
            unrecognizedRights: [], unrecognizedFlags: []
        )
        let desired = AccessControlList(entries: [entry])
        let item = EscalatedAttributeBatch.Item(
            path: VFSPath.local("/a"), actsOnLink: false, current: attributes(),
            diff: AttributeDiff(),
            currentACL: nil, accessControlList: desired
        )
        let batch = EscalatedAttributeBatch(items: [item])
        #expect(item.desiredACL == desired)
        #expect(item.currentACL == AccessControlList(), "no list before is the empty list")

        let landed = batch.outcome { _ in .init(attributes: attributes(), accessControlList: desired) }
        #expect(landed.unchanged.isEmpty)
        #expect(landed.changed.first?.accessControlLists?.new == desired)
        #expect(landed.changed.first?.accessControlLists?.old == AccessControlList())

        let refused = batch.outcome { _ in .init(
            attributes: attributes(),
            accessControlList: .init()
        ) }
        #expect(refused.unchanged == [VFSPath.local("/a")])
        #expect(refused.changed.isEmpty)
    }

    // MARK: - Retrying a recursive run's root-only items

    @Test("A recursive run keeps the items it left for root, deepest first, for the retry")
    func runnerKeepsRootOnlyItems() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let stranger = UserContext(userID: 31337, groupIDs: [20])
        let job = AttributeApplyJob(patch: fixture.patch(mode: 0o700))

        let report = AttributeApplyRunner.run(
            job, sources: [try fixture.entry()], using: fixture.backend, actor: stranger
        )
        let outcome = try fixture.outcome(report)

        #expect(outcome.rootOnly.map(\.path) == report.failures.map(\.path))
        #expect(outcome.rootOnly.count == 6)
        #expect(outcome.rootOnly.first?.path == fixture.tree.vfsPath("sub/deep/c.txt"))
        #expect(outcome.rootOnly.last?.path == fixture.tree.vfsPath(""))
        #expect(
            outcome.rootOnly.first { $0.path == fixture.tree.vfsPath("sub") }?.kind == .directory
        )
    }

    @Test("The retry plans each item again, and its bodies apply the whole run as it would have")
    func retryAppliesTheRun() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let stranger = UserContext(userID: 31337, groupIDs: [20])
        let job = AttributeApplyJob(patch: fixture.patch(mode: 0o700))
        let report = AttributeApplyRunner.run(
            job, sources: [try fixture.entry()], using: fixture.backend, actor: stranger
        )
        let rootOnly = try fixture.outcome(report).rootOnly
        // Already matching by the time the dialog comes up: it drops out.
        #expect(chmod(fixture.tree.path("a.txt"), 0o700) == 0)

        let batch = EscalatedAttributeBatch(retrying: rootOnly, of: job)
        #expect(batch.items.count == 5)
        #expect(!batch.items.contains { $0.path == fixture.tree.vfsPath("a.txt") })

        for body in batch.bodies() {
            #expect(try runShell(body).status == 0)
        }
        let outcome = batch.outcomeOnDisk()

        for relative in ["", "sub", "sub/deep", "sub/b.txt", "sub/deep/c.txt"] {
            #expect(try fixture.mode(relative) == 0o700, "\(relative)")
        }
        #expect(outcome.changedCount == 5)
        #expect(outcome.unchanged.isEmpty)
        let record = try #require(UndoRecord.attributeBatchChange(outcome.changed))
        #expect(record.steps.count == 5)
    }

    @Test("The retry drops an item that has gone")
    func retryDropsMissingItem() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let job = AttributeApplyJob(patch: fixture.patch(mode: 0o700))
        let rootOnly: [AttributeApplyOutcome.RootOnlyItem] = [
            .init(path: fixture.tree.vfsPath("gone.txt"), kind: .file),
            .init(path: fixture.tree.vfsPath("a.txt"), kind: .file)
        ]
        let batch = EscalatedAttributeBatch(retrying: rootOnly, of: job)
        #expect(batch.items.map(\.path) == [fixture.tree.vfsPath("a.txt")])
    }
}
