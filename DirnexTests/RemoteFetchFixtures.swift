import DirnexCore
import Foundation

/// Fixtures shared by `RemoteFileCacheTests` and `RemotePreviewFetchTests`.
///
/// One cache tested from two sides — what it *remembers*, and what its cursor-following fetch
/// *does* — so the entry builder and the counting backend belong to neither file. Split out when
/// the second half took the original past SwiftLint’s 500-line ceiling.
///
/// At file scope rather than on a suite: `CountingBackend` is `Sendable` and answers from
/// whichever thread the transfer runs on, so it cannot reach a main-actor-isolated static.
enum Fixture {
    static let backendID = VFSBackendID.s3(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    )

    static func entry(
        _ name: String,
        byteSize: Int64 = 12,
        modified: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backendID, path: "/\(name)"),
            name: name,
            kind: .file,
            byteSize: byteSize,
            modificationDate: modified,
            creationDate: modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }
}

/// A main-actor counter for the landing callback. A plain `var` captured by an `@escaping
/// @MainActor` closure cannot be mutated from it; a tiny reference type can.
@MainActor
final class Landing {
    var times = 0
}

/// A backend that answers a download with known bytes and counts every call it is asked to make.
///
/// Counting rather than asserting-on-call: the claim is about a *number of requests* over a
/// sequence of gestures, which no single expectation inside the fake could express.
final class CountingBackend: VFSBackend, @unchecked Sendable {
    enum Outcome {
        case succeed
        /// Write a short prefix and then throw, the shape a stopped `curl` now leaves.
        case cancel
        case fail
        /// Sit in the transfer until `isCancelled` says otherwise — a stand-in for the seconds a
        /// real object spends on the wire, which every other outcome here finishes too fast to have.
        case block
    }

    static let body = "downloaded!"
    /// How much a `.block` transfer reports having moved before it parks.
    static let blockedChunk: Int64 = 7
    /// The longest a `.block` transfer will sit there if nobody ever stops it.
    ///
    /// **A backstop against a leaked thread, and never a duration any assertion may rest on.** It
    /// used to be 500 × 10 ms, which made it both — and the arithmetic that hid inside it broke a
    /// test. `usleep` runs on a `BlockingWork` thread that nothing can starve, so the transfer ended
    /// at a fixed 5 s of wall clock, while every observer of it is scheduled on the **main actor**,
    /// which in a full run of this suite is delayed by seconds at a time: measured 2026-08-27, the
    /// main queue and the main actor stall together for 0.6–5.0 s while AppKit lays out the tables
    /// of panes other suites keep alive, and the progress sheet a 1200 ms timer asks for actually
    /// appeared **2.9–7.3 s** in. Past 5 s the transfer had finished, so the sheet went up and was
    /// torn down in the same drain of the main actor — 55 ms of visible life in one measured run —
    /// and a poll loop getting one sample a second missed it about once in sixteen runs. Everything
    /// downstream (`wasCancelledMidTransfer`, the cache's `.stopped` record) went the same way,
    /// silently, because the transfer had already run to its own end.
    ///
    /// So it is long enough that no wait in these suites can outlive it, and every test that starts
    /// one stops it — this only bounds the damage if one ever stops doing so.
    ///
    /// **Shortening it is the amplification**, and it is what turns the diagnosis into a
    /// measurement: at 2 s the transfer reliably ends before the sheet is serviced, and both sheet
    /// tests then fail **3 of 3** full runs with the reporter's own message —
    /// `(window → <NSWindow: …>).attachedSheet → nil → nil`. At 60 s the same tree is green, and
    /// the sheet is taken down by the test that was watching it rather than by this clock.
    static let blockBackstop: TimeInterval = 60

    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let outcome: Outcome
    private let lock = NSLock()
    private var counts = (copy: 0, stat: 0, list: 0)
    private var destination: String?
    private var observedCancellation = false

    init(outcome: Outcome = .succeed) {
        self.outcome = outcome
    }

    var copyCount: Int { lock.withLock { counts.copy } }
    var statCount: Int { lock.withLock { counts.stat } }
    var listCount: Int { lock.withLock { counts.list } }
    var lastDestination: String? { lock.withLock { destination } }
    /// Whether a `.block` transfer was actually told to stop, as opposed to running to its own
    /// backstop. The assertion a cancellation test rests on: `throws CancellationError` is not
    /// evidence here for the same reason it was not in Slice 10's probe — the caller's own boundary
    /// check throws whether or not anything was interrupted.
    var wasCancelledMidTransfer: Bool { lock.withLock { observedCancellation } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.withLock { counts.list += 1 }
        return []
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        lock.withLock { counts.stat += 1 }
        return Fixture.entry(path.lastComponent)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        lock.withLock {
            counts.copy += 1
            self.destination = destination.path
        }
        switch outcome {
        case .succeed:
            try Data(Self.body.utf8).write(to: URL(fileURLWithPath: destination.path))
            progress(Int64(Self.body.utf8.count))
        case .cancel:
            try Data("dow".utf8).write(to: URL(fileURLWithPath: destination.path))
            progress(3)
            throw CancellationError()
        case .fail:
            throw VFSError.notFound(source)
        case .block:
            // Report a chunk *before* blocking, so a progress reader has something to find: a
            // transfer that only reports at the end is indistinguishable from one reporting nothing.
            progress(Self.blockedChunk)
            // On `BlockingWork`'s global queue, not a cooperative worker, which is the whole reason
            // that type exists — so sleeping here spends a thread the pool will replace rather than
            // one the process shares (docs/NOTES.md ▸ Swift 6 and concurrency).
            let backstop = Date().addingTimeInterval(Self.blockBackstop)
            while !isCancelled(), Date() < backstop {
                usleep(10_000)
            }
            guard isCancelled() else { return }
            lock.withLock { observedCancellation = true }
            throw CancellationError()
        }
    }
}
