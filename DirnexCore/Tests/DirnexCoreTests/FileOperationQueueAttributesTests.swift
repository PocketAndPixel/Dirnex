import Foundation
import Testing

@testable import DirnexCore

/// The recursive-attributes kind's ride on the shared operation queue (PLAN.md §M14 Slice 4).
///
/// Its own file for the reason the checksum one has: `FileOperationQueueTests` is already at
/// SwiftLint's type-body ceiling, and the seam is real — these assert that a job which moves no
/// bytes still gets the scheduler, the cancel and the report channel a copy gets, and that the bar
/// it draws has something to draw from.
@Suite("FileOperationQueue — attributes")
struct FileOperationQueueAttributesTests {
    private func makeJob(mode: UInt16) -> AttributeApplyJob {
        var patch = AttributePatch()
        patch.permissionMask = POSIXPermissions(rawValue: 0o7777)
        patch.permissionValues = POSIXPermissions(rawValue: mode)
        return AttributeApplyJob(patch: patch, target: .filesOnly)
    }

    @Test("a recursive apply runs through the same queue and brings its undo material home")
    func runsAttributeJob() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("sub")
        try tree.writeFile("a.txt", contents: "alpha\n")
        try tree.writeFile("sub/b.txt", contents: "beta\n")

        let backend = LocalBackend()
        let queue = FileOperationQueue(backend: backend)
        let operation = FileOperation(
            kind: .attributes(makeJob(mode: 0o750)),
            sources: [try backend.stat(at: tree.vfsPath())],
            destinationDirectory: tree.vfsPath()
        )
        let id = await queue.enqueue(operation)
        await queue.waitUntilIdle()

        let job = try #require(await queue.snapshot().jobs.first { $0.id == id })
        #expect(job.status == .finished)
        let outcome = try #require(job.report?.attributeApply)
        #expect(outcome.changedCount == 3, "the root plus both files")
        #expect(outcome.isUndoable)
        #expect(
            try FileAttributeIO.read(at: tree.vfsPath("sub/b.txt"))
                .attributes.permissions.rawValue == 0o750
        )
    }

    /// A job that moves no bytes would otherwise leave the bar at zero for its whole run and then
    /// jump to full — which reads as a hang on the operation that can take longest to look at.
    @Test("the aggregate has items to draw a bar from, even with no bytes in sight")
    func aggregateFallsBackToItems() async throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "alpha\n")

        let backend = LocalBackend()
        let queue = FileOperationQueue(backend: backend)
        await queue.enqueue(FileOperation(
            kind: .attributes(makeJob(mode: 0o750)),
            sources: [try backend.stat(at: tree.vfsPath())],
            destinationDirectory: tree.vfsPath()
        ))
        await queue.waitUntilIdle()

        let aggregate = await queue.snapshot().aggregate
        #expect(aggregate.totalBytes == 0, "nothing was moved, and the readout must not pretend")
        #expect(aggregate.totalItems == 2)
        #expect(aggregate.completedItems == 2)
        #expect(aggregate.fraction == 1)
    }

    /// The undo material comes off the report's payload, never off `outcomes` — there are none,
    /// because nothing moved. `UndoRecord.transfer` returning `nil` for this kind is the compile-time
    /// reminder of that.
    @Test("transfer has nothing to say about an attributes job")
    func transferDeclinesTheKind() {
        #expect(UndoRecord.transfer(
            kind: .attributes(makeJob(mode: 0o644)), outcomes: []
        ) == nil)
    }
}
