import Foundation
import Testing

@testable import DirnexCore

/// The `.writeBack` job: a batch of edited copies going back to their servers as one queued run
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// What these pin is the half a live server cannot show cheaply — that the batch is **ordered**,
/// that one item's refusal does not abandon the other thirty-nine, that a Stop names exactly what
/// had already gone up, and that a precondition is never quietly dropped. The fake records what it
/// was asked to send, because the claim is *which writes reach the wire in which order*: a double
/// that merely succeeded would prove the runner calls something.
@Suite("WriteBackRunner")
struct WriteBackRunnerTests {
    private let remote = VFSBackendID.sftp(SFTPLocation(host: "srv", username: "oleg"))

    private func destination(_ name: String) -> VFSPath {
        VFSPath(backend: remote, path: "/home/oleg/\(name)")
    }

    private func item(
        _ name: String,
        bytes: Int64 = 100,
        condition: S3WriteCondition = .unconditional
    ) -> RemoteWriteBackItem {
        RemoteWriteBackItem(
            localPath: "/tmp/edits/\(name)",
            destination: destination(name),
            condition: condition,
            byteSize: bytes,
            name: name
        )
    }

    private func operation(_ items: [RemoteWriteBackItem]) -> FileOperation {
        FileOperation(
            kind: .writeBack(WriteBackJob(items: items)),
            sources: [],
            destinationDirectory: VFSPath(backend: remote, path: "/home/oleg")
        )
    }

    @Test("every item is written, in the order the batch was assembled")
    func writesEveryItemInOrder() {
        let backend = RecordingWriteBackBackend()
        let report = WriteBackRunner.run(
            operation([item("a.txt"), item("b.txt"), item("c.txt")]),
            using: backend
        )
        #expect(report.succeeded)
        // Order is the whole of "no ordering" in the gap this closed: forty independent `Task`s had
        // none, and a batch that re-sorted its items would be inventing a second one.
        #expect(
            backend.sent.map(\.local) == ["/tmp/edits/a.txt", "/tmp/edits/b.txt", "/tmp/edits/c.txt"]
        )
        #expect(
            report.writtenBack == [destination("a.txt"), destination("b.txt"), destination("c.txt")]
        )
        #expect(report.completedItems == 3)
    }

    @Test("one item's refusal does not abandon the rest")
    func oneRefusalDoesNotStopTheBatch() throws {
        // The choice a batch makes and a single save cannot see: thirty-nine edits must not be lost
        // because the fortieth file's server said no.
        let backend = RecordingWriteBackBackend()
        backend.failing = ["/tmp/edits/b.txt"]
        let report = WriteBackRunner.run(
            operation([item("a.txt"), item("b.txt"), item("c.txt")]),
            using: backend
        )
        #expect(!report.succeeded)
        #expect(report.writtenBack == [destination("a.txt"), destination("c.txt")])
        let failure = try #require(report.failures.first)
        #expect(failure.path == destination("b.txt"))
        #expect(report.failures.count == 1)
    }

    @Test("stopping names exactly what had already gone up")
    func cancellationNamesWhatLanded() {
        // An upload cannot be taken back, so a count is not enough: the caller has to re-baseline
        // precisely the items that landed, and leaving a stale revision on one would have our own
        // write read back later as "someone else has edited it".
        //
        // Cancellation is read off the backend's own record rather than a captured counter, since
        // the runner's `isCancelled` is `@Sendable` — which is the same reason the runner hands its
        // progress closure constants (docs/NOTES.md ▸ Swift 6 and concurrency).
        let backend = RecordingWriteBackBackend()
        let report = WriteBackRunner.run(
            operation([item("a.txt"), item("b.txt"), item("c.txt")]),
            using: backend,
            isCancelled: { backend.writeCount >= 2 }
        )
        #expect(report.wasCancelled)
        #expect(report.writtenBack == [destination("a.txt"), destination("b.txt")])
        #expect(backend.sent.count == 2)
    }

    @Test("the bar's denominator is known before the first byte moves")
    func progressIsDeterminateFromTheStart() throws {
        // Every source is a file on this disk, so unlike a materialize — whose folders can only be
        // measured when their turn comes — there is nothing here a listing could fail to state.
        let backend = RecordingWriteBackBackend()
        let updates = Updates()
        _ = WriteBackRunner.run(
            operation([item("a.txt", bytes: 100), item("b.txt", bytes: 300)]),
            using: backend,
            onProgress: { updates.append($0) }
        )
        let seen = updates.all
        let first = try #require(seen.first)
        #expect(first.totalBytes == 400)
        #expect(seen.allSatisfy { $0.totalBytes == 400 })
        #expect(seen.last?.completedItems == 1) // the last update is the second item starting
    }

    @Test("a precondition travels to the backend rather than being dropped")
    func conditionIsCarried() {
        // Per item, never per job: a batch is a set of independent files with their own entity
        // tags, and one condition shared across them could only ever be `.unconditional`.
        let backend = RecordingWriteBackBackend()
        _ = WriteBackRunner.run(
            operation([
                item("a.txt", condition: .ifMatches(entityTag: "\"aaa\"")),
                item("b.txt")
            ]),
            using: backend
        )
        #expect(backend.sent.map(\.condition) == [.ifMatches(entityTag: "\"aaa\""), .unconditional])
    }

    @Test("a job of another kind is nothing to do rather than a trap")
    func wrongKindIsEmpty() {
        let report = WriteBackRunner.run(
            FileOperation(kind: .materialize, sources: [], destinationDirectory: .local("/tmp")),
            using: RecordingWriteBackBackend()
        )
        #expect(report == .empty)
        #expect(report.writtenBack == nil)
    }

    @Test("a batch that landed nothing answers empty rather than nothing")
    func landedNothingIsEmptyNotNil() {
        // Different answers: a caller reading the destinations has to tell "this job wrote nothing"
        // from "this was not a write-back".
        let backend = RecordingWriteBackBackend()
        backend.failing = ["/tmp/edits/a.txt"]
        let report = WriteBackRunner.run(operation([item("a.txt")]), using: backend)
        #expect(report.writtenBack == [])
    }

    /// Progress updates, collected off whatever thread the runner reports on.
    private final class Updates: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [OperationProgress] = []
        func append(_ update: OperationProgress) {
            lock.lock(); updates.append(update); lock.unlock()
        }

        var all: [OperationProgress] {
            lock.lock(); defer { lock.unlock() }; return updates
        }
    }
}

/// A backend that records the save-backs it was asked to perform.
private final class RecordingWriteBackBackend: VFSBackend, @unchecked Sendable {
    struct Write: Equatable {
        let local: String
        let destination: VFSPath
        let condition: S3WriteCondition
    }

    /// Local paths whose write should fail, so a batch's per-item failure rule is reachable.
    var failing: Set<String> = []
    private(set) var sent: [Write] = []

    /// How many writes have been accepted — what a `@Sendable` `isCancelled` can read to stop the
    /// run at a known point.
    var writeCount: Int {
        lock.lock(); defer { lock.unlock() }; return sent.count
    }

    private let lock = NSLock()

    var id: VFSBackendID { VFSBackendID("test-writeback") }
    var capabilities: VFSCapabilities { [.read, .write] }
    func listDirectory(at _: VFSPath) throws -> [FileEntry] { [] }
    func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }

    func writeBack(
        localPath: String,
        to destination: VFSPath,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Bool {
        guard !failing.contains(localPath) else { throw VFSError.permissionDenied(destination) }
        lock.lock()
        sent.append(Write(local: localPath, destination: destination, condition: condition))
        lock.unlock()
        progress(1)
        return condition.isConditional
    }
}
