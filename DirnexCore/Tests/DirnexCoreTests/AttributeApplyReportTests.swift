import Foundation
import Testing

@testable import DirnexCore

/// What a recursive attributes apply *leaves behind* (PLAN.md §M14 Slice 4): the undo material, the
/// cap on it, the failures it collects rather than aborts on, and the count the confirmation sheet
/// shows. What it writes is `AttributeApplyRunnerTests`.
@Suite("AttributeApplyRunner report")
struct AttributeApplyReportTests {
    // MARK: - Undo material

    @Test("Every changed item is journaled with its own before and after")
    func journalsEachChangedItem() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o750), target: .filesOnly)
        )
        let result = try fixture.outcome(report)

        #expect(result.isUndoable)
        #expect(result.changed.count == result.changedCount)
        #expect(result.changed.allSatisfy { $0.old.permissions.rawValue != 0o750 })
        #expect(result.changed.allSatisfy { $0.new.permissions.rawValue == 0o750 })

        // And the record it builds really puts the tree back.
        let record = try #require(UndoRecord.attributeBatchChange(result.changed))
        _ = UndoJournal.revert(record, using: fixture.backend)
        #expect(try fixture.mode("a.txt") == 0o644)
        #expect(try fixture.mode("sub/b.txt") == 0o644)
        #expect(try fixture.mode("sub/deep/c.txt") == 0o644)
    }

    /// Over the cap the run journals **nothing** rather than an arbitrary first slice: reverting part
    /// of a tree leaves it in a state the user cannot reason about (``AttributeApplyJob/journalLimit``).
    @Test("Over the journal limit the run reports the change and drops the undo material")
    func overTheJournalLimitDropsEverything() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(AttributeApplyJob(
            patch: fixture.patch(mode: 0o750), target: .filesOnly, journalLimit: 2
        ))
        let result = try fixture.outcome(report)

        #expect(result.changedCount == 4, "the work still happened in full")
        #expect(try fixture.mode("sub/deep/c.txt") == 0o750)
        #expect(!result.isUndoable)
        #expect(result.changed.isEmpty)
        #expect(UndoRecord.attributeBatchChange(result.changed) == nil)
    }

    @Test("A run that exactly reaches the limit is still undoable")
    func atTheLimitIsUndoable() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let report = try fixture.run(AttributeApplyJob(
            patch: fixture.patch(mode: 0o750), target: .filesOnly, journalLimit: 4
        ))
        let result = try fixture.outcome(report)

        #expect(result.changedCount == 4)
        #expect(result.isUndoable)
        #expect(result.changed.count == 4)
    }

    // MARK: - Cancellation

    @Test("A cancel stops the walk and keeps what it already changed undoable")
    func cancelKeepsWhatItDid() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let counter = CancellationCounter()
        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o600)),
            isCancelled: { counter.increment() > 3 }
        )
        let result = try fixture.outcome(report)

        #expect(report.wasCancelled)
        #expect(result.changedCount < 6, "a cancelled run must not have finished the tree")
        #expect(result.changed.count == result.changedCount)
        #expect(result.isUndoable, "a partial run is still one Cmd+Z")
    }

    // MARK: - Failures

    @Test("A non-local source is refused by name rather than half-run")
    func nonLocalSourceIsRefused() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }
        let remote = FileEntry(
            path: VFSPath(backend: VFSBackendID("sftp"), path: "/home/oleg/x"),
            name: "x",
            kind: .file,
            byteSize: 0,
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )

        let report = AttributeApplyRunner.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o600)),
            sources: [remote],
            using: fixture.backend
        )

        #expect(report.failures.count == 1)
        #expect(report.failures.first?.error == .unsupported(.attributesNeedLocalItem(name: "x")))
    }

    /// A run that hits an item it cannot change collects the failure and keeps going, unlike the flat
    /// sheet which pre-flights and refuses. A tree walk that stopped at the first foreign file would
    /// leave the rest half-changed with nothing to say where it got to.
    @Test("An item needing root is a named failure, and the rest of the tree still runs")
    func rootOnlyItemIsCollectedNotFatal() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        // Pretend to be a different user: every item then reads as someone else's.
        let stranger = UserContext(userID: 31337, groupIDs: [20])
        let report = AttributeApplyRunner.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o600), target: .filesOnly),
            sources: [try fixture.entry()],
            using: fixture.backend,
            actor: stranger
        )

        #expect(report.failures.count == 4, "every in-scope item is named")
        #expect(report.failures.allSatisfy {
            if case .unsupported(.attributeChangeNeedsAdministrator) = $0.error { return true }
            return false
        })
        #expect(try fixture.outcome(report).changedCount == 0)
        #expect(try fixture.mode("a.txt") == 0o644, "and nothing was written")
    }

    // MARK: - Counting

    @Test("The count matches what the run visits, because both use the same walk")
    func countMatchesTheRun() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let counted = AttributeApplyRunner.count(
            sources: [try fixture.entry()], target: .filesOnly, using: fixture.backend
        )
        let report = try fixture.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o600), target: .filesOnly)
        )

        #expect(counted == 4)
        #expect(try fixture.outcome(report).visitedCount == counted)
    }

    /// Marking a folder *and* something inside it makes the inner item both a root and a child.
    /// Applying twice is harmless; counting it twice would make the confirmation sheet and the
    /// report disagree over a selection the user made deliberately.
    @Test("An item that is both a root and a child is visited once")
    func overlappingSourcesAreVisitedOnce() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let sources = [try fixture.entry(), try fixture.entry("sub/b.txt")]
        let counted = AttributeApplyRunner.count(
            sources: sources, target: .everything, using: fixture.backend
        )
        let report = AttributeApplyRunner.run(
            AttributeApplyJob(patch: fixture.patch(mode: 0o750)),
            sources: sources,
            using: fixture.backend
        )

        #expect(counted == 6, "six items, not seven")
        #expect(try fixture.outcome(report).visitedCount == 6)
    }

    @Test("Counting the whole tree includes its directories")
    func countEverything() throws {
        let fixture = try AttributeApplyFixture()
        defer { fixture.cleanup() }

        let counted = AttributeApplyRunner.count(
            sources: [try fixture.entry()], target: .everything, using: fixture.backend
        )

        #expect(counted == 6)
    }
}
