import DirnexCore
import Foundation

/// Watches one running transfer so it can report where it has got to, for whichever observable the
/// tool in question actually offers (PLAN.md §M21 Slice 12).
///
/// All three remote transports spawn one long-lived child and park the operation engine's thread on
/// `ProcessWaiting.wait`; this is what that loop reads on every turn. The rules for turning an
/// observation into a delta are the core's (``TransferProgressTally``), and what lives here is the
/// part that cannot be pure: reading a file's size, and holding the meter across two threads.
///
/// The choice of observable is the caller's rather than something inferred here, because the two
/// are not interchangeable and a wrong guess is silent:
///
/// - A **download** writes a file on this machine, so its size is the byte count — exact, free, and
///   needing nothing of the tool.
/// - An **upload** changes nothing locally, so the only thing that knows is `curl`'s own percentage
///   meter, at one-per-cent resolution. `sftp` has no equivalent at any resolution (probed six ways;
///   `SFTPTransport.upload`), which is why one of the four transfer verbs across the three transports
///   passes `.none` and reports at the end.
/// - A **parallel** transfer has neither: several sections share one meter. An upload's batch reads
///   the indexed write-out lines its own sections print, and a download's reads the several files it
///   is writing — which is the same "watch what grows" rule as a single download, over a set.
final class TransferProgressWatch: @unchecked Sendable {
    /// What to watch while the transfer runs.
    enum Source {
        /// Nothing to watch: a metadata request, or an upload whose tool prints no meter.
        case none
        /// A destination file on this machine, whose size is the exact count of what has landed.
        case destinationFile(path: String)
        /// `curl`'s percentage meter on stderr, against a total the caller knows exactly.
        case uploadMeter(totalBytes: Int64)
        /// A **parallel** part upload's own write-out lines, with each part's length — the only
        /// observable a batch has, since several transfers share one meter and nothing local grows.
        /// A part reports its whole length the moment its `s3-part<n>-status=` line lands.
        case uploadedParts(lengths: [Int: Int64])
        /// A **parallel** segmented download's part files, and the object's total size. Their
        /// combined length is what has landed — exact and free, where the batch's own write-out
        /// lines could only ever step a whole segment at a time (docs/HISTORY.md ▸ After M19).
        ///
        /// The total is a **cap**, not a target: an endpoint that answers a `Range` request with
        /// the whole object writes every section a full copy, and without it the bar would report
        /// several times the file's size into a job total that only adds. The backend detects that
        /// answer and re-fetches in one stream, so the cap is what keeps the report honest in the
        /// meantime.
        case destinationFiles(paths: [String], totalBytes: Int64)
    }

    private let source: Source
    private let lock = NSLock()
    private var meter = CurlProgressMeter()
    /// Fed the same text as the meter, and read only by ``Source/uploadedParts(lengths:)``. Two
    /// readers rather than one because they answer different questions of the same stream: the
    /// meter reads `curl`'s table, this reads the labels we asked `curl` to print.
    private var parts = S3PartWriteOut()
    private var tally: TransferProgressTally

    init(_ source: Source) {
        self.source = source
        // A resume starts with bytes already in the destination that are not this transfer's to
        // report. Read at construction — i.e. before the child is spawned — since afterwards the
        // file is growing and the baseline would include some of what is being measured. Only the
        // single-file case can have one: a segmented download's part files are created by the run
        // being watched, so there is never anything already in them.
        if case let .destinationFile(path) = source {
            tally = TransferProgressTally(destinationAlreadyHolds: Self.fileSize(path))
        } else {
            tally = TransferProgressTally()
        }
    }

    /// Fold the next chunk of the child's stderr in.
    func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        meter.consume(text)
        parts.consume(text)
    }

    /// Report whatever has landed since the last turn. Called on the waiting thread — the operation
    /// engine's own — so the byte count reaches the job's tally on the thread that owns it.
    func report(to progress: (Int64) -> Void) {
        guard let delta = nextDelta() else { return }
        progress(delta)
    }

    /// The delta to report now, computed under the lock and handed back so `progress` is called
    /// outside it — that closure reaches the operation queue, and nothing this file owns should be
    /// held while it runs.
    private func nextDelta() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        switch source {
        case .none:
            return nil
        case let .destinationFile(path):
            return tally.delta(forDestinationSize: Self.fileSize(path))
        case let .uploadMeter(totalBytes):
            guard let moved = meter.bytesTransferred(ofTotal: totalBytes) else { return nil }
            return tally.delta(movedSoFar: moved)
        case let .uploadedParts(lengths):
            let moved = parts.completedParts.reduce(0) { $0 + (lengths[$1] ?? 0) }
            return tally.delta(movedSoFar: moved)
        case let .destinationFiles(paths, totalBytes):
            let landed = paths.reduce(0) { $0 + Self.fileSize($1) }
            return tally.delta(movedSoFar: min(landed, totalBytes))
        }
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }
}
