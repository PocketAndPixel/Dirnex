import Foundation
import Testing

@testable import DirnexCore

/// What **one job** could not carry, as opposed to what a connection has lost since it opened
/// (PLAN.md §M25 Slice 5b).
///
/// The distinction is the whole slice. Slice 2's accumulator spans a connection's life, which is the
/// right expiry for a fact about a server and the wrong window for a sentence about a copy — a user
/// told "the modification times weren't kept" after their second transfer must not be being told
/// about their first.
@Suite("Per-job metadata loss")
struct RemoteMetadataLossReportTests {
    // MARK: - The arithmetic

    @Test("a delta counts only what happened after the earlier reading")
    func deltaExcludesWhatCameBefore() {
        let before = RemoteMetadataTally(itemCount: 3, perAspect: [.modificationTime: 3])
        let after = RemoteMetadataTally(itemCount: 5, perAspect: [.modificationTime: 5, .mode: 1])
        let delta = after.since(before)
        #expect(delta.itemCount == 2)
        #expect(delta.perAspect == [.modificationTime: 2, .mode: 1])
    }

    @Test("an aspect already lost before the run is not re-reported when it does not recur")
    func settledAspectIsNotReReported() {
        // The reason the accumulator counts per aspect instead of keeping a set: a *set* difference
        // cannot tell "lost again" from "lost earlier", so this run would inherit the last one's
        // aspects for as long as the connection lived.
        let before = RemoteMetadataTally(itemCount: 4, perAspect: [.mode: 4])
        let after = RemoteMetadataTally(itemCount: 5, perAspect: [.mode: 4, .modificationTime: 1])
        let delta = after.since(before)
        #expect(delta.perAspect == [.modificationTime: 1])
        #expect(delta.loss?.aspects == [.modificationTime])
    }

    @Test("a reading taken across a reconnection cannot go negative")
    func deltaClampsAtZero() {
        // The two readings can come from different accumulators — a dropped and re-established
        // connection answers from a fresh one — so the later reading can be the smaller.
        let delta = RemoteMetadataTally.zero.since(
            RemoteMetadataTally(itemCount: 9, perAspect: [.mode: 9])
        )
        #expect(delta.itemCount == 0)
        #expect(delta.loss == nil)
    }

    @Test("two accounts' losses add up, which is what a relayed copy needs")
    func talliesAdd() {
        let sftp = RemoteMetadataTally(itemCount: 2, perAspect: [.modificationTime: 2])
        let ftp = RemoteMetadataTally(itemCount: 1, perAspect: [.mode: 1, .accessTime: 1])
        let total = sftp.adding(ftp)
        #expect(total.itemCount == 3)
        #expect(total.perAspect == [.modificationTime: 2, .mode: 1, .accessTime: 1])
    }

    @Test("nothing lost is nothing to say")
    func zeroHasNoLoss() {
        #expect(RemoteMetadataTally.zero.loss == nil)
        // Aspects with no count is a reading taken across a reconnection, not a loss anybody had.
        #expect(RemoteMetadataTally(itemCount: 0, perAspect: [.mode: 0]).loss == nil)
    }

    @Test("the accumulator counts each aspect per item")
    func supportCountsPerAspect() {
        let support = RemoteMetadataSupport(offering: .sftp)
        support.record(dropped: [.modificationTime])
        support.record(dropped: [.modificationTime, .specialModeBits])
        support.record(dropped: [])
        #expect(support.tally.itemCount == 2)
        #expect(support.tally.perAspect == [.modificationTime: 2, .specialModeBits: 1])
    }

    // MARK: - What a job reports

    @Test("a copy that carried everything reports no loss")
    func cleanCopyReportsNothing() throws {
        let fixture = try LossFixture(dropping: [])
        let report = fixture.copy()
        #expect(report.metadataLoss == nil)
        #expect(report.failures.isEmpty)
    }

    @Test("a copy that dropped something reports it, with a count")
    func lossyCopyReportsIt() throws {
        let fixture = try LossFixture(dropping: [.modificationTime])
        let report = fixture.copy()
        let loss = try #require(report.metadataLoss)
        #expect(loss.aspects == [.modificationTime])
        #expect(loss.itemCount == 1)
    }

    /// **The test this slice exists for.** Two copies over one connection: the second must report
    /// its own loss and not the first's, which is exactly what reading the connection's
    /// ``RemoteMetadataSupport/loss`` would have done.
    @Test("a second job reports its own loss, never the first job's")
    func secondJobDoesNotInheritTheFirst() throws {
        let fixture = try LossFixture(dropping: [.modificationTime])
        let first = fixture.copy()
        #expect(first.metadataLoss?.itemCount == 1)

        let second = fixture.copy(named: "b.txt")
        let loss = try #require(second.metadataLoss)
        #expect(loss.itemCount == 1) // not 2 — the connection's running total is 2 by now
        #expect(fixture.backend.tally(for: fixture.remoteRoot).itemCount == 2)
    }

    @Test("a job that lost nothing after one that did still reports nothing")
    func cleanJobAfterALossyOneIsClean() throws {
        // The narrowness control for the delta: without it a connection that ever lost anything
        // would report a loss on every later copy for the rest of its life.
        let fixture = try LossFixture(dropping: [.mode])
        _ = fixture.copy()
        fixture.dropping = []
        #expect(fixture.copy(named: "b.txt").metadataLoss == nil)
    }
}

/// A backend that copies for real onto a temp tree and reports whatever loss the test asks for.
///
/// Built on `LocalBackend` so the copy actually happens — the claim is about what the **report**
/// says, and a backend that moved no bytes would let a broken engine pass by producing no report at
/// all. The loss is injected rather than provoked because provoking one needs a server, and what is
/// under test here is the arithmetic between the readings.
private final class LossFixture {
    let root: URL
    let backend: LossyBackend
    var dropping: Set<RemoteMetadataAspect> {
        get { backend.dropping }
        set { backend.dropping = newValue }
    }

    var remoteRoot: VFSPath { .local(root.appendingPathComponent("dst").path) }

    init(dropping: Set<RemoteMetadataAspect>) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dst"),
            withIntermediateDirectories: true
        )
        backend = LossyBackend(dropping: dropping)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func copy(named name: String = "a.txt") -> OperationReport {
        let source = root.appendingPathComponent("src/\(name)")
        try? Data("bytes".utf8).write(to: source)
        let entry = (try? backend.stat(at: .local(source.path)))!
        return CopyEngine.run(
            FileOperation(kind: .copy, sources: [entry], destinationDirectory: remoteRoot),
            using: backend
        )
    }
}

/// A local backend that also keeps a ``RemoteMetadataSupport``, so a job's delta has something to
/// measure. Every file it copies records `dropping` against that accumulator, exactly as a real
/// remote backend's transfer does.
private final class LossyBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let metadata = RemoteMetadataSupport(offering: .sftp)
    var dropping: Set<RemoteMetadataAspect>

    init(dropping: Set<RemoteMetadataAspect>) { self.dropping = dropping }

    func tally(for path: VFSPath) -> RemoteMetadataTally { metadataTally(at: path) }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }
    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    // No clone, so the engine takes the chunked path that actually calls `copyFile`.
    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
        metadata.record(dropped: dropping)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func metadataTally(at _: VFSPath) -> RemoteMetadataTally { metadata.tally }
}
