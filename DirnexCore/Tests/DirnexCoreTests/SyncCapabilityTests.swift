import Foundation
import Testing

@testable import DirnexCore

@Suite("SyncDirection — what a pair of sides permits")
struct SyncDirectionAvailabilityTests {
    @Test("two writable sides get every direction, in on-screen order")
    func twoWritableSides() {
        #expect(
            SyncDirection.available(leftAcceptsChanges: true, rightAcceptsChanges: true)
                == [.leftToRight, .bidirectional, .rightToLeft]
        )
    }

    /// A read-only bucket is a perfectly ordinary thing to mirror *from*, so what is withdrawn is
    /// the direction that would write to it — never the sheet.
    @Test("a read-only side withdraws only the directions that would change it")
    func readOnlySideWithdrawsWrites() {
        #expect(
            SyncDirection.available(leftAcceptsChanges: true, rightAcceptsChanges: false)
                == [.rightToLeft]
        )
        #expect(
            SyncDirection.available(leftAcceptsChanges: false, rightAcceptsChanges: true)
                == [.leftToRight]
        )
    }

    @Test("two read-only sides leave nothing to run")
    func twoReadOnlySides() {
        #expect(
            SyncDirection.available(leftAcceptsChanges: false, rightAcceptsChanges: false).isEmpty
        )
    }
}

@Suite("SyncDeletePlan — what a sync's deletions really do")
struct SyncDeletePlanTests {
    private let local = VFSPath.local("/tmp/local.txt")
    private let remote = VFSPath(
        backend: .sftp(SFTPLocation(host: "example.test", username: "oleg")),
        path: "/srv/remote.txt"
    )
    private let readOnly = VFSPath(
        backend: .archive(forArchiveAt: "/tmp/a.zip"),
        path: "/inside.txt"
    )

    private func strategy(_ path: VFSPath) -> DeleteStrategy {
        switch path {
        case local: .trash
        case remote: .permanent
        default: .unsupported
        }
    }

    /// The shape the widened gate makes ordinary — a local pane against a server — and the one the
    /// single-sentence confirmation was wrong about.
    @Test("a mixed run splits, and both halves are counted")
    func mixedRunSplits() {
        let plan = SyncDeletePlan(paths: [local, remote, readOnly], strategy: strategy)
        #expect(plan.toTrash == [local])
        #expect(plan.permanent == [remote])
        #expect(plan.unsupported == [readOnly])
        #expect(plan.count == 2)
        #expect(!plan.isEmpty)
    }

    /// An item nothing will touch must not be counted in a sentence saying it will.
    @Test("items that cannot be deleted are named but not counted")
    func unsupportedIsNotCounted() {
        let plan = SyncDeletePlan(paths: [readOnly], strategy: strategy)
        // Hoisted: SwiftLint reads `plan.count == 0` as an `isEmpty` it should prefer, and `isEmpty`
        // here deliberately answers a *different* question — it ignores `unsupported`, which is the
        // very distinction under test.
        let willBeDeleted = plan.count
        #expect(plan.isEmpty)
        #expect(willBeDeleted == 0)
        #expect(plan.unsupported == [readOnly])
    }

    @Test("order is preserved within each bucket")
    func orderPreserved() {
        let second = VFSPath.local("/tmp/second.txt")
        let plan = SyncDeletePlan(paths: [local, second]) { _ in .trash }
        #expect(plan.toTrash == [local, second])
    }

    @Test("a purely local run is what it always was")
    func localOnlyRun() {
        let plan = SyncDeletePlan(paths: [local], strategy: strategy)
        #expect(plan.permanent.isEmpty)
        #expect(plan.unsupported.isEmpty)
        #expect(plan.toTrash == [local])
    }
}
